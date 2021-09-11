package ar.labs.krishilens;

public class CourseModel {

    // string course_name for storing course_name
    // and imgid for storing image id.
    private String course_name;
    private String title;
    private int imgid;

    public CourseModel(String course_name, int imgid,String title) {
        this.course_name = course_name;
        this.imgid = imgid;
        this.title=title;
    }

    public String getCourse_name() {
        return course_name;
    }

    public void setCourse_name(String course_name) {
        this.course_name = course_name;
    }

    public int getImgid() {
        return imgid;
    }

    public void setImgid(int imgid) {
        this.imgid = imgid;
    }
    public String getTitle() {
        return title;
    }
    public void  setTitle() {
        this.title=title;
    }
}
